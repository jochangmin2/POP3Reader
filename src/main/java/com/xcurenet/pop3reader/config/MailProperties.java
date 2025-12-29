package com.xcurenet.pop3reader.config;

import lombok.Data;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.context.config.annotation.RefreshScope;
import org.springframework.stereotype.Component;

import java.util.Properties;

@Data
@Component
@RefreshScope
public class MailProperties {

	@Value("${mail.store.protocol:pop3}")
	private String mailStoreProtocol;

	@Value("${mail.pop3.host:pop3.daouoffice.com}")
	private String mailPop3Host;

	@Value("${mail.pop3.port:110}")
	private int mailPop3Port;

	@Value("${mail.pop3.username}")
	private String mailPop3Username;

	@Value("${mail.pop3.password}")
	private String mailPop3Password;

	@Value("${mail.pop3.fatch.count:10}")
	private int mailPop3FetchCount;

	public Properties getProperties() {
		Properties props = new Properties();
		props.put("mail.store.protocol", mailStoreProtocol);
		props.put("mail.pop3.host", mailPop3Host);
		props.put("mail.pop3.port", mailPop3Port);
		return props;
	}
}